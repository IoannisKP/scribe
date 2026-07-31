# Scribe

Scribe is a local-first macOS meeting transcription application. It is being
built as a native SwiftUI app for Apple Silicon and macOS 14.4 or newer.

## Current status

Milestones 1 through 3 are implemented. Milestones 1A through 1D provide
the native app, the foundational `AudioCapture` module, isolated two-track
recording, and the complete first-run permission experience:

- a preallocated single-producer, single-consumer Float32 ring buffer;
- allocation-free planar-channel mono mixdown in the realtime callback;
- mono Float32 sample-rate conversion through `AVAudioConverter`;
- a streaming 16 kHz mono Float32 WAV writer with recoverable headers;
- microphone permission handling with actionable denied/restricted states;
- `AVAudioEngine` microphone capture with device-change and sleep/wake recovery;
- a Core Audio mono process tap that excludes Scribe's own process;
- a private aggregate device with the real output device as its main
  subdevice and the process tap attached as a drift-compensated subtap;
- direct system-audio reads through `AudioDeviceCreateIOProcIDWithBlock`;
- recovery for default output changes, tap format changes, aggregate death,
  Core Audio service restarts, sleep, and wake;
- first-run microphone and system-audio permission cards with accurate
  last-observed states and direct links to their separate privacy panes;
- an explicit system-audio permission check that briefly starts a Core Audio
  tap, discards its samples, and writes no file;
- visible per-track starting, recording, recovery, stopping, and failure state;
- a working two-track record/stop UI that reveals both WAVs in Finder;
- unit tests for FIFO behavior, planar mixdown, permission paths, resampling a
  known sine sweep, aggregate composition, partial-failure coordination, and
  WAV output.

Milestone 2 adds the `SpeechPipeline` foundation and local Parakeet batch
transcription:

- the public `TranscriptionEngine` contract, including engine-selected window
  duration and overlap, plus audio, word-timing, and transcript-segment values;
- `capture-session.json`, which records each source's offset on the shared
  monotonic session timeline;
- bounded canonical-WAV reads sized by the selected engine instead of loading
  an entire long meeting into memory;
- overlapping batch reads advance by window minus overlap and pass each
  source through seam de-duplication before the shared timeline is merged;
- chronological dispatch and deterministic merging across microphone and
  system tracks;
- strict validation of engine timing and source attribution;
- FluidAudio 0.15.5, pinned exactly for reproducible Core ML behavior;
- Parakeet TDT 0.6B v3 for 25 European languages, including English, Swedish,
  and Greek, plus Parakeet v2 as an English-only option;
- explicit model availability and download state under Scribe's own
  Application Support directory;
- a strict offline inference path: engine preparation refuses an incomplete
  cache and enables FluidAudio offline mode before loading Core ML;
- timestamp mapping from Parakeet's chunk-local words onto the shared
  two-source session timeline;
- utterance rows use the first and last mapped word as their visible bounds;
  backend duration is used only when word timing is unavailable;
- local model selection, download progress, batch progress, and an interleaved
  timestamped transcript in the app;
- mock-engine, adapter, missing-model, fixture-backed WAV, and opt-in Core ML
  acceptance tests.

Milestone 3A establishes the bounded live-audio handoff consumed by the live
speech pipeline:

- each source's canonical 16 kHz blocks are offered to the live pipeline only
  after the same samples have been committed to its durable WAV;
- microphone and system blocks retain independent, contiguous source-relative
  sample indices;
- a `LiveAudioTransport` actor immediately appends blocks to separate
  sequential spool files instead of retaining an unbounded in-memory queue;
- hysteretic **keeping up**, **buffering to disk**, and **catching up** states
  make backpressure visible in the recording UI;
- live-pipeline failures stop that feed and surface an actionable error without
  invalidating the independently durable recording;
- deterministic tests cover file round trips, source continuity, backpressure,
  and a virtual one-hour/two-source feed whose peak transport memory is one
  block.

Milestone 3B adds offline, per-source speech detection and bounded ASR-window
preparation:

- an explicit **Download Live VAD** action installs Silero under Scribe's
  model directory; recording and inference never initiate a download;
- the compiled Core ML model is loaded manually with FluidAudio offline mode
  enabled, avoiding its download-capable convenience initializer;
- microphone and system audio have independent Silero recurrent states and
  threshold hysteresis;
- silence-aware segments use 150 ms minimum speech, 750 ms trailing silence,
  100 ms padding, and an exact 30-second continuous-speech ceiling;
- speech is emitted with the selected engine's window and overlap geometry
  (14 seconds and 1.5 seconds for Parakeet);
- windows are written to source-specific transient files, so waiting for the
  next live stage does not create an unbounded memory queue;
- source- and timeline-aware overlap de-duplication prefers word timings and
  falls back to normalized text tokens;
- the recording UI shows model acquisition and live speech-pipeline state;
- deterministic tests cover source isolation, segmentation, window overlap,
  spool round trips, de-duplication, and a virtual one-hour bounded-buffer
  soak.

Milestone 3C completes local live transcription:

- the selected downloaded Parakeet engine consumes VAD windows while capture
  continues, entirely outside the main actor;
- long active speech emits partial rows before its boundary; the final
  overlapping tail replaces the same stable row after seam de-duplication;
- short utterances appear as final rows when Silero confirms their trailing
  silence;
- rows remain chronologically interleaved across **You** and **Others** using
  the shared capture timeline;
- if ASR falls behind, source-specific window files absorb the queue and the UI
  reports **buffering to disk** then **catching up**; Scribe never silently
  changes the selected model;
- missing or failed Parakeet leaves recording and VAD operational with an
  explicit recording-only status;
- the live view marks rows **Partial** or **Final** and updates by stable
  identity rather than appending duplicate seams;
- integration tests exercise raw transport → per-source VAD → disk window
  spool → live ASR, plus a virtual one-hour/two-source run whose peak in-flight
  audio is one bounded window.

FluidAudio's existing Parakeet adapter is window-based rather than token
streaming. Consequently, short phrases finalize after their speech boundary,
while continuous speech first produces a partial after a full 14-second window
plus overlap is available. No network is used.

## Requirements

- Apple Silicon Mac
- macOS 14.4 or newer
- Xcode 26.6 or another Xcode release that supports Swift 6 strict concurrency

## Build and test

Open `Scribe.xcworkspace`, select the `Scribe` scheme, and run the app.

On first launch, complete **Set up recording**:

1. Click **Allow Microphone** and approve the macOS prompt.
2. Click **Check System Audio Access** and approve the system-audio prompt.
   This check discards captured samples and creates no recording.
3. Click **Continue to Recording**.

Press **Record meeting**, play system audio, speak at the same time, then press
**Stop recording** and use **Show WAVs in Finder**. The results are separate
16 kHz mono Float32 files:

- `microphone.wav` contains the local microphone;
- `system.wav` contains other processes routed to the current output device.

To transcribe:

1. Choose **Parakeet v3 · Multilingual** or **Parakeet v2 · English**.
2. Click **Download Model**. This explicit action is the only model-network
   path.
3. After the model is available, click **Transcribe Recording**.
4. Read the merged rows labelled **You** and **Others**. Their timestamps use
   the shared monotonic capture timeline.

Downloaded model artifacts are large. The app shows real download and Core ML
compilation progress; interruption can leave an incomplete cache that remains
unavailable until Download Model is run again.

To prepare live speech detection:

1. Click **Download Live VAD** before recording. This is an explicit,
   user-initiated network operation.
2. Start recording after the model reports downloaded.
3. Confirm **Speech detection running** appears under the live-feed state.
4. Stop recording normally so the source spools are fully drained and removed.

If the VAD model is missing or fails to load, Scribe continues saving both WAV
tracks and explains that the session is recording-only.

For live transcription, both **Live VAD** and the selected **Parakeet** model
must report downloaded before recording starts. Model selection is locked for
the active session. Missing ASR never prevents recording.

From Terminal:

```sh
swift test
xcodebuild \
  -project Scribe.xcodeproj \
  -scheme Scribe \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Permissions

The app declares:

- `NSMicrophoneUsageDescription` for the user's microphone;
- `NSAudioCaptureUsageDescription` for system audio captured with a Core Audio
  process tap;
- `com.apple.security.device.audio-input` for audio input under the hardened
  runtime.

The app is non-sandboxed because the planned private aggregate audio device
cannot be used reliably within App Sandbox. Hardened runtime is enabled.

Microphone permission has a public AVFoundation authorization-status API, so
Scribe can read its current state. Core Audio process taps have no public TCC
preflight/status API. Apple documents that the prompt occurs the first time an
aggregate containing a tap starts. Scribe therefore reports system-audio
permission only as **Not checked**, **Allowed (last checked)**, or **Denied**,
based on a real no-file tap check or recording attempt. It never reads the TCC
database or uses a private framework.

When access is denied, the permission screen links directly to:

- **Privacy & Security → Microphone**;
- **Privacy & Security → Screen & System Audio Recording → System Audio
  Recording Only**.

After changing system-audio access in Settings, return to Scribe and click
**Check Again**.

For Mac App Store distribution, the audio architecture would need to be
reassessed against the then-current sandbox rules. In particular, aggregate
device creation and process-tap access would need a sandbox-compatible design
or an explicitly permitted alternative. The sandbox capability, container-safe
storage paths, and App Store signing profile would then need to be enabled.

## Dependencies

- [FluidAudio](https://github.com/FluidInference/FluidAudio) `0.15.5`, exact
  revision `19600a485baa4998812e4654b70d2bab8f2c9949`.

Both Swift Package Manager entry points are locked: the root
`Package.resolved` supports command-line tests and the Xcode project's
`Package.resolved` supports app builds.

## Data locations

The finished app will keep models and application data under:

```text
~/Library/Application Support/Scribe/
```

Parakeet models are stored under:

```text
~/Library/Application Support/Scribe/Models/parakeet-tdt-0.6b-v3-coreml/
~/Library/Application Support/Scribe/Models/parakeet-tdt-0.6b-v2-coreml/
```

Silero VAD is stored under:

```text
~/Library/Application Support/Scribe/Models/silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/
```

Microphone recordings are stored under:

```text
~/Library/Application Support/Scribe/Sessions/<session UUID>/microphone.wav
~/Library/Application Support/Scribe/Sessions/<session UUID>/system.wav
~/Library/Application Support/Scribe/Sessions/<session UUID>/capture-session.json
```

The JSON file contains only canonical format metadata, relative audio paths,
and the two track-start offsets. It contains no transcript or captured audio.

While recording, Milestone 3A creates source-specific transient files under:

```text
~/Library/Application Support/Scribe/Sessions/<session UUID>/LiveSpool/
```

These sequential files bound live-pipeline memory when processing falls behind.
They are removed on orderly stop or failed startup. The WAV files remain the
durable recording of record.

Milestone 3B also creates speech-window records under:

```text
~/Library/Application Support/Scribe/Sessions/<session UUID>/LiveSpeechWindows/
```

Those records contain only VAD-selected canonical samples and window metadata.
They bound memory until live ASR is attached in Milestone 3C and are removed
when the session stops. They do not replace the WAV files.

WAV tests write only to a unique temporary directory and remove it after each
test.

To wipe future local Scribe data, quit the app and remove the specific
`~/Library/Application Support/Scribe/` directory. Do not remove the broader
Application Support directory.

The first-run completion flag and last-observed system-audio permission state
are ordinary local preferences under Scribe's preferences domain. macOS owns
the actual privacy grants; change or revoke them in System Settings rather than
editing TCC data.

## Milestone 1 acceptance check

This check requires user consent and real audio hardware, so it is intentionally
manual:

1. Complete both permission cards.
2. Start a recording.
3. Play a spoken YouTube video while speaking into the microphone.
4. While recording, change the default output between speakers and headphones;
   confirm the system track briefly reports recovery and returns to Recording.
5. Stop and reveal the WAV files.
6. Inspect both files in an audio editor:
   - both are 16,000 Hz, mono, 32-bit Float WAV;
   - `microphone.wav` contains the local voice but not direct digital playback;
   - `system.wav` contains browser playback but not Scribe's own output;
   - both files remain independently seekable and playable.

Acoustic speaker-to-microphone bleed is physically possible when using open
speakers. Use headphones when checking source isolation.

## Milestone 2 acceptance check

This check downloads a model once and then runs locally:

1. Record a short meeting with distinct speech on microphone and system audio.
2. Select Parakeet v3 and click **Download Model**.
3. Disconnect the Mac from the network after the model reports Downloaded.
4. Click **Transcribe Recording**.
5. Confirm timestamped **You** and **Others** rows are interleaved by when each
   phrase occurred, including the small startup offset between tracks.
6. Repeat with Parakeet v2 for an English recording if that model is installed.

The ordinary suite includes a committed 19.6-second canonical Float32 WAV made
with macOS `say` and its known reference text. When the selected Parakeet model
is installed, the suite transcribes that fixture and enforces a word-error-rate
ceiling. When it is missing, the test skips with the exact model name and local
directory required. The synthetic voice is clean and contains no disfluency,
room noise, cross-talk, or accent variation; this is a deterministic regression
guard, not evidence of real-world accuracy.

An optional second golden run remains available for caller-supplied recorded
audio and reference text:

```sh
SCRIBE_RUN_PARAKEET_GOLDEN=1 \
SCRIBE_GOLDEN_MODEL=v3 \
SCRIBE_GOLDEN_WAV=/absolute/path/to/known-speech.wav \
SCRIBE_GOLDEN_TEXT='known reference text' \
SCRIBE_GOLDEN_MAX_WER=0.25 \
swift test --filter ParakeetGoldenFileTests
```

Ordinary test runs never download a model or access the network. They run the
committed fixture only when the local model is already complete. The opt-in
variables affect only the additional real-recording fixture; `SCRIBE_GOLDEN_MODEL`
and `SCRIBE_GOLDEN_MAX_WER` can also select v2 or override the ceiling.

## Milestone 3A acceptance check

This submilestone validates the live transport and backpressure boundary; it
does not yet display transcript text while recording:

1. Start a recording and confirm the live-feed label moves from **ready** to
   **keeping up**.
2. With Live VAD installed, continue for at least ten seconds and confirm the
   VAD consumer normally keeps the raw feed drained. Disk-buffering and
   catch-up states remain visible if processing stalls.
3. Stop recording and confirm both WAVs remain valid and the live feed reports
   a clean stop.
4. Run `swift test`; the `LiveAudioTransportTests` suite includes the
   deterministic one-hour/two-source bounded-memory feed.

## Milestone 3B acceptance check

This check requires the one-time VAD download and real input sources:

1. Click **Download Live VAD** and wait for the downloaded/offline status.
2. Disconnect the Mac from the network.
3. Record alternating speech and silence on both microphone and system audio.
4. Confirm the UI reports that speech detection is running while both WAVs
   continue recording.
5. Speak continuously for more than 30 seconds, then stop. Confirm speech
   detection finishes without blocking the UI and both WAVs remain valid.
6. Run `swift test`; the `LiveSpeechPipelineTests` and
   `TranscriptOverlapDeduplicatorTests` suites verify the exact 30-second
   ceiling, 14-second windows, 1.5-second overlaps, source offsets, transient
   spool round trips, seam removal, and bounded one-hour silence processing.

The ordinary suite also runs a committed Parakeet batch-seam regression when
the selected model is installed. It places a window boundary inside a word
identified by one-window inference and requires the overlapped result to retain
the baseline word count while remaining within the golden WER threshold.

## Milestone 3C acceptance check

This check uses the already-downloaded VAD and Parakeet models:

1. Disconnect the Mac from the network.
2. Select a downloaded Parakeet model and start recording.
3. Speak briefly, pause for at least one second, and confirm a final **You**
   row appears.
4. Play system speech and confirm final **Others** rows use the system track's
   timeline offset.
5. Speak continuously for longer than 16 seconds. Confirm a **Partial** row
   appears and is replaced by a **Final** row after silence or the 30-second
   ceiling, without duplicated overlap text.
6. Stop while ASR has queued work. Confirm the UI reports disk buffering or
   catch-up, then completion, while both WAVs remain valid.
7. Run `swift test`; `LiveTranscriptionPipelineTests` covers partial
   replacement, seam removal, attribution failure, backpressure hysteresis,
   full transport/VAD/spool/ASR integration, and the virtual one-hour
   two-source bounded-window soak.

## Privacy

The project contains no telemetry, analytics, crash reporter, or cloud
transcription client. Recording and inference do not use the network. The only
network paths are the user-initiated Parakeet and Silero model downloads.
