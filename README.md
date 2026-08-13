# Scribe

Scribe is a local-first macOS meeting transcription application. It is being
built as a native SwiftUI app for Apple Silicon and macOS 26 or newer.

## Current status

Milestones 1 through 3 are implemented. Milestones 1A through 1D provide
the native app, the foundational `AudioCapture` module, isolated two-track
recording, and the complete first-run permission experience:

- a preallocated single-producer, single-consumer Float32 ring buffer;
- allocation-free planar-channel mono mixdown in the realtime callback;
- mono Float32 sample-rate conversion through `AVAudioConverter`;
- a streaming 16 kHz mono Int16 PCM WAV writer with recoverable headers;
- microphone permission handling with actionable denied/restricted states;
- `AVAudioEngine` microphone capture with device-change and sleep/wake recovery;
- a Core Audio mono process tap that excludes Scribe's own process;
- a private aggregate device with the real output device as its main
  subdevice and the process tap attached as a drift-compensated subtap;
- direct system-audio reads through `AudioDeviceCreateIOProcIDWithBlock`;
- launch-time prewarming of the private tap, aggregate, and unstarted IOProc,
  with the 7.32 MiB ring and WAV writer deferred until Record;
- recovery for default output changes, tap format changes, aggregate death,
  Core Audio service restarts, sleep, and wake;
- first-run microphone and system-audio permission cards with accurate
  last-observed states and direct links to their separate privacy panes;
- an explicit system-audio permission check that briefly starts a Core Audio
  tap, discards its samples, and writes no file;
- visible per-track starting, recording, recovery, stopping, and failure state;
- disk-space preflight and monitoring that finalize both WAVs before the
  configured safety reserve is consumed;
- a working two-track record/stop UI that reveals both WAVs in Finder;
- unit tests for FIFO behavior, planar mixdown, permission paths, resampling a
  known sine sweep, aggregate composition, partial-failure coordination, and
  WAV output.

Milestone 2 adds the `SpeechPipeline` foundation and local Parakeet batch
transcription:

- the public `TranscriptionEngine` contract, including engine-selected window
  duration and overlap, plus audio, word-timing, and transcript-segment values;
- `session.json`, which records stable session identity, artifact inventory,
  transcription history, and each source's offset on the shared timeline;
- bounded canonical-WAV reads sized by the selected engine instead of loading
  an entire long meeting into memory;
- overlapping batch reads advance by window minus overlap and pass each
  source through seam de-duplication before the shared timeline is merged;
- chronological dispatch and deterministic merging across microphone and
  system tracks;
- equal absolute starts always order **You** (microphone) before **Others**
  (system), regardless of utterance length; the system manifest offset is
  applied before that comparison;
- Core Audio nil-data render buffers use their reported frame count to append
  silence, preserving system-track elapsed time through rendering gaps; a
  genuinely header-only system track remains a valid silent meeting side;
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
  100 ms padding, and a 30-second baseline continuous-speech ceiling that grows
  to fit the selected engine's window plus overlap;
- speech is emitted with the selected engine's window and overlap geometry
  (14 seconds and 1.5 seconds for Parakeet);
- windows are written to source-specific transient files, so waiting for the
  next live stage does not create an unbounded memory queue;
- source- and timeline-aware overlap de-duplication prefers word timings and
  falls back to normalized text tokens;
- the recording UI shows model acquisition and live speech-pipeline state;
- unavailable and backlog statuses name the observed component: Silero for
  speech detection, Parakeet for ASR, and live audio for transport buffering;
- deterministic tests cover source isolation, segmentation, window overlap,
  spool round trips, de-duplication, and a virtual one-hour bounded-buffer
  soak.

Milestone 3C completes local live transcription:

- the selected downloaded Parakeet engine consumes VAD windows while capture
  continues, entirely outside the main actor;
- long active speech emits partial rows before its boundary; the final
  overlapping tail replaces the same stable row after seam de-duplication;
- ceiling-forced continuations carry the selected overlap into a new stable row
  and may correct only the preceding final row's overlap tail in place;
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
- successful live completion writes the same current Markdown, JSON, and SRT
  exports and immutable transcription-history revision as batch transcription;
  captured audio remains intact if those exports cannot be saved.

FluidAudio's existing Parakeet adapter is window-based rather than token
streaming. Consequently, short phrases finalize after their speech boundary,
while continuous speech first produces a partial after a full 14-second window
plus overlap is available. Whisper follows the same rule with its 30-second
window, so its engine-derived ceiling is 31.5 seconds. No network is used.

Milestone 4 now has a standalone, dependency-free `ModelManager` framework. Its
validated built-in catalogue gives Parakeet v3/v2, Silero, and twelve verified
Whisper variants stable identities plus language, installation, geometry,
quantization, speed, and measured resource metadata. Parakeet and Silero share
one managed registry and FluidAudio adapter; Whisper uses a separate adapter
behind the same manager policy. Existing caches are used in place without
copying or redownloading them.
The manager also defines a provider-neutral acquisition controller with explicit
downloading, pausing, paused, verifying, installed, cancelled, and failed states.
Downloads remain in a staging folder until a bounded-memory SHA-256/size pass
succeeds; pause tokens are handed to the provider transport, cancellation removes
partial staging, and invalid artifacts are never promoted as installed models.
The provider adapters obtain exact sizes and LFS SHA-256 values from official
Hugging Face trees; regular Git artifacts below the Hub's 10 MiB large-file
boundary are downloaded and SHA-256 hashed directly. Provider cache-shape
validation also runs while files are still staged.
Model storage accounting uses the files actually present on disk, including
allocated size, without following symbolic links. Download and load safety use
evidence-backed artifact and peak-memory profiles plus configurable disk and RAM
reserves. If a requirement or capacity reading is unknown, the evaluator returns
a denied result with a specific reason instead of guessing from parameter counts.
SpeechPipeline links only the individual WhisperKit product from the renamed
Argmax open-source SDK at exact version 1.0.0. Tiny, Tiny English, Base, Small,
Medium, Large v3, Large v3 Turbo, Distil Large v3, and four compressed/optimized
variants have each produced a committed golden WER measurement. The adapter
requires the exact selected local folder, disables implicit downloading, uses
30-second windows with 1.5-second overlap, and preserves word timestamps. These
models are exposed alongside both Parakeet choices in the catalogue-driven app
menu. The model card shows provider, languages, compression, speed, measured
installed size and peak memory, current safety status, and total library usage.
Installs can be paused, resumed, or cancelled; installed or invalid entries can
be moved to Trash without touching recordings. A shared resident-engine coordinator
unloads the prior exact engine before preparing another, rejects switching
during inference, and prevents stale wrappers from unloading or transcribing
through the newly selected model.

The committed switching comparison loads Parakeet v3, then Whisper Tiny, Small,
and Medium through one resident coordinator and transcribes the same fixture
with each. Measured WERs are 0.0000, 0.0588, 0.0000, and 0.0000 respectively.
Missing local models are named and skipped; tests never download implicitly.

## Requirements

- Apple Silicon Mac
- macOS 26 or newer. macOS 25 and earlier are no longer supported: Milestone 5A
  establishes macOS 26 as the sole compatibility baseline before the session
  store and interface are built, while Scribe is still pre-release and can
  avoid carrying legacy branches into its foundational data model.
- Xcode 26.6 or another Xcode release that supports Swift 6 strict concurrency

## Build and test

### Local code signing

Copy `Config/LocalSigning.xcconfig.example` to
`Config/LocalSigning.xcconfig`, then replace `YOUR_TEAM_ID` with the Apple
Development team selected in your Xcode account. The local file supplies the
team, identity, signing style, and provisioning override through the tracked
`Config/Signing.xcconfig` hook.

`LocalSigning.xcconfig` is ignored by Git. Each builder can therefore use a
different team without modifying `project.pbxproj` or producing a repository
diff. Automated and unsigned builds do not require the local file.

Open `Scribe.xcworkspace`, select the `Scribe` scheme, and run the app.

On first launch, complete **Set up recording**:

1. Click **Allow Microphone** and approve the macOS prompt.
2. Click **Check System Audio Access** and approve the system-audio prompt.
   This check discards captured samples and creates no recording.
3. Click **Continue to Recording**.

Press **Record meeting**, play system audio, speak at the same time, then press
**Stop recording** and use **Show WAVs in Finder**. The results are separate
16 kHz mono Int16 PCM files:

- `microphone.wav` contains the local microphone;
- `system.wav` contains other processes routed to the current output device.

Capture, VAD, and transcription continue to process Float32 samples. Only the
durable files are quantized to Int16, halving their audio payload. Existing
16 kHz mono Float32 Scribe recordings remain readable and transcribable.

To transcribe:

1. Choose an exact Parakeet or verified Whisper entry under **Models and local
   transcription**. The choice is saved as the default and fixed when a live
   recording starts.
2. Review its language, disk, peak-memory, and safety information, then click
   **Install**. This explicit action is the only model-network path. Large
   transfers expose **Pause**, **Resume**, and **Cancel**.
3. After the model is installed, click **Transcribe Recording**.
4. Read the merged rows labelled **You** and **Others**. Their timestamps use
   the shared monotonic capture timeline.

If the exact selection is missing or fails, Scribe names it and may offer the
closest smaller model already installed. It changes models only when that offer
is clicked. **Move to Trash…** moves only the selected model folder to macOS
Trash after confirmation, so it remains recoverable until Trash is emptied.
Silero VAD has the same explicit install/recoverable-remove treatment.

Downloaded model artifacts are large. The app shows real download and Core ML
compilation progress. New downloads stay under the manager's hidden staging
folder until provider validation and checksum verification finish. A managed
pause keeps completed staged files so a later resume can skip them.

To prepare live speech detection:

1. Click **Install Silero VAD** before recording. This is an explicit,
   user-initiated network operation.
2. Start recording after the model reports installed.
3. Confirm **Speech detection running** appears under the live-feed state.
4. Stop recording normally so the source spools are fully drained and removed.

If the VAD model is missing or fails to load, Scribe continues saving both WAV
tracks and explains that the session is recording-only.

For live transcription, both **Silero VAD** and the exact selected transcription
model must report installed before recording starts. Model selection is locked
for the active session. Missing ASR never prevents recording.

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
- [Argmax OSS / WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
  `1.0.0`, exact revision `25c62997041c134b03ca82731ce2f6fd2cae1eb9`.
- [GRDB](https://github.com/groue/GRDB.swift) `7.11.1`, exact revision
  `b83108d10f42680d78f23fe4d4d80fc88dab3212`. GRDB has no transitive package
  dependencies. It compiles under Swift 6 complete strict concurrency at the
  macOS 26 target with no warnings in either Debug or Release.

Both Swift Package Manager entry points use exact requirements. The committed
root `Package.resolved` locks command-line builds, while the Xcode project stores
the same exact requirements and resolves its workspace lockfile locally.

Resolving GRDB increased `.build` from 3,321,520 KiB to 3,715,368 KiB: a
393,848 KiB (384.6 MiB) increase before compilation. The checkout accounted for
158,436 KiB and SwiftPM's bare repository cache for 234,604 KiB. After the first
Debug compile, `.build` was 3,814,024 KiB, a net increase of 492,504 KiB
(481.0 MiB) from the pre-GRDB baseline. Direct compiled GRDB objects and its
Swift module account for another 30,268 KiB; the remaining growth is shared
SwiftPM build planning and index data. Xcode's separate DerivedData is not
included in these figures.

## Data locations

Models and the rebuildable session index remain under:

```text
~/Library/Application Support/Scribe/
```

Parakeet models are stored under:

```text
~/Library/Application Support/Scribe/Models/parakeet-tdt-0.6b-v3/
~/Library/Application Support/Scribe/Models/parakeet-tdt-0.6b-v2/
```

Silero VAD is stored under:

```text
~/Library/Application Support/Scribe/Models/silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/
```

Sessions now default to ordinary folders under `~/Documents/Scribe`, or a
user-selected folder retained through a security-scoped bookmark:

```text
~/Documents/Scribe/2026-08-11 11.30 — Meeting/
    session.json
    microphone.wav
    system.wav
    notes.md
    transcript.md
    transcript.json
    transcript.srt
    Transcriptions/<date — model — revision>/transcript.{md,json,srt}
```

`session.json` contains the stable UUID, title, creation date, source type,
canonical format, relative track paths, speaker identities, artifact inventory,
and transcription history. Speaker IDs are stable session metadata independent
of any transcript revision. Each legacy or new single-speaker source receives a
deterministic `source.<source>` identity; the registry also permits multiple
speakers per source and records whether a display name was machine- or
user-assigned. Renaming a speaker updates the manifest without rewriting audio
or immutable transcript history.

New live tracks store their relative starts as integer 16 kHz sample
offsets derived from their first captured audio timestamps. The microphone uses
`AVAudioTime.hostTime`; the system IOProc uses `inInputTime.mHostTime`, which
describes the first acquired frame rather than the IO thread's wake time. The
tick delta is converted with `mach_timebase_info` and normalized so the earlier
track begins at sample zero. An empty track has no invented timestamp.

Version-1 `capture-session.json` remains readable and is migrated to
`session.json`. Its seconds-based start value is rounded to the nearest
canonical sample and explicitly marked `legacyEstimated`; old recordings are
never presented as having timing precision that was not captured.

GRDB and FTS5 index session metadata, transcript, notes, and summary text under
`~/Library/Application Support/Scribe/Index`. Session folders are authoritative:
the database can be deleted and deterministically rebuilt. Launch, activation,
pre-recording checks, and debounced FSEvents trigger reconciliation. If a
removable or network location is unavailable, existing rows are marked
unavailable and never interpreted as mass deletion.

Session UUID, not folder path, is identity. A Finder rename or move updates only
the indexed path. If a folder is duplicated, the older folder keeps its UUID;
the newer copy receives a fresh UUID and is indexed as an independent session.
This is informational and requires no repair from the user.

Additional regular user documents and media are surfaced when their extensions
identify common documents, images, audio, or video. Hidden files, `.DS_Store`,
Finder aliases, symbolic links, packages, editor/temporary/download fragments,
unknown binary types, and Scribe's transient live spool folders are ignored.

Transcript word arrays are normalized by absolute timestamp before segment
bounds, overlap trimming, row ordering, or future seek positions are derived.
Every successful transcription writes the current Markdown, JSON, and SRT
artifacts and an immutable model/date revision under `Transcriptions`, so
re-transcription never destroys the earlier durable transcript.

The shared transcript paragrapher powers durable Markdown now and both transcript
views in Milestone 5B. It breaks after sentence-ending words followed by a pause
strictly longer than 400 ms, forces a boundary at the latest sentence ending once
a paragraph would exceed 45 seconds, and otherwise uses the largest word gap in
that span. A source or speaker change is always a hard boundary. If word timings
are absent or cannot reproduce the provider text safely, the original segment is
kept intact so paragraphing cannot lose or rewrite transcript content.

Audio and video files can be imported through **File → Import audio or video…**
or Command-O. The placeholder window also accepts a file drop through one root
drop handler; the designed sessions-library drop target remains part of the
views order. Import creates one session source, never synthetic “You” and
“Others” tracks:

```text
~/Documents/Scribe/2026-08-11 12.00 — Interview/
    Interview.mov             # original bytes and filename retained
    audio.wav                 # 16 kHz mono Int16 derivative
    notes.md
    session.json              # source=importedFile, original name and format
    transcript.md
    transcript.json
    transcript.srt
    Transcriptions/<date — model — revision>/transcript.{md,json,srt}
```

`AVAssetReader` decodes only the first audio track and streams bounded sample
buffers into the existing durable Int16 writer; video frames are never decoded
or copied into `audio.wav`. Batch transcription then uses the selected engine
and emits `.imported` segments. Markdown and the app's transcript rows omit a
source label, while JSON records `"source": "imported"`. The manifest contains
one logical audio track and two audio-related artifacts, allowing the reading
view to show **Audio 1** while listing both original and derivative.

Unsupported files, corrupt assets, playable video without an audio track, and
assets with no samples produce distinct actionable failures and leave the
source untouched. A multi-hour file is copied and converted sequentially with
bounded memory; time and disk use scale with duration, with the canonical WAV
adding 32,000 bytes per second before transcription artifacts. RIFF's 4 GiB
payload ceiling is about 37.3 hours at this format. A source already in canonical
format is still retained independently and decoded into a separate derivative.
If its filename is already `audio.wav`, the byte-identical original is stored as
`Original/audio.wav` so the required canonical derivative can keep the reserved
root name.

Before capture starts, Scribe checks the recording volume against a configurable
expected duration (two hours by default) and a configurable 512 MiB free-space
reserve. The estimate is deliberately conservative: 320,000 bytes per second
allows for both durable Int16 tracks and worst-case simultaneous raw and speech
window Float32 spools. That is about 1.15 GB per hour while the durable WAVs
alone total about 230 MB per hour. During capture Scribe checks every five
seconds; reaching the reserve stops both tracks through their normal finalizers.
Failure to query free space also triggers the same safe stop.

While recording, Milestone 3A creates source-specific transient files under:

```text
<session folder>/LiveSpool/
```

These sequential files bound live-pipeline memory when processing falls behind.
They are removed on orderly stop or failed startup. The WAV files remain the
durable recording of record.

Milestone 3B also creates speech-window records under:

```text
<session folder>/LiveSpeechWindows/
```

Those records contain only VAD-selected canonical samples and window metadata.
They bound memory until live ASR is attached in Milestone 3C and are removed
when the session stops. They do not replace the WAV files.

The source checkout can itself occupy several gigabytes because SwiftPM keeps
FluidAudio, Argmax OSS, and compiled dependencies under `.build`; Xcode keeps a
separate DerivedData cache outside the checkout. The Argmax OSS source checkout
is small compared with compiled artifacts, but caches can grow after new
configurations or toolchain versions are built. Whisper model downloads and
meeting sessions live under Application Support, not inside the source checkout.
During the Milestone 4 all-model verification, the checkout remained about
3.1 GB while the model library reached roughly 11–12 GB. The twelve supported Whisper
installations alone total 11,582,028,876 logical bytes. Normal users do not need
every model installed; the model card reports actual total usage and can remove
one exact installation without touching source, other models, or sessions.
Scribe also scans for folders directly under `Models` that are not present in
the catalogue. It displays each unrecognized folder with its recursive logical
size and file count, includes that space in the total, and offers removal only
after an explicit confirmation. Known model folders, the `.Downloads` staging
area, files, and symbolic links are not offered through this cleanup control.
Confirmed cleanup moves the selected intact folder to macOS Trash instead of
unlinking it permanently.

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
   - both are 16,000 Hz, mono, 16-bit PCM WAV;
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
5. Speak continuously past the selected engine's ceiling (30 seconds for
   Parakeet and 31.5 seconds for Whisper), then stop. Confirm speech
   detection finishes without blocking the UI and both WAVs remain valid.
6. Run `swift test`; the `LiveSpeechPipelineTests` and
   `TranscriptOverlapDeduplicatorTests` suites verify engine-aware ceilings,
   selected window geometry, 1.5-second overlaps, source offsets, transient
   spool round trips, seam removal, and bounded one-hour silence processing.

The ordinary suite also runs a committed Parakeet batch-seam sweep when the
selected model is installed. A production-sized 14-second/1.5-second window grid
is shifted across whole-second fixture positions from 2 through 18 seconds. The
test reports substitution, insertion, and deletion counts at 125, 250, and
500 ms seam tolerances, rejects any dropped reference word, and applies a 0.06
WER ceiling derived from the measured distribution to the production path.
Batch stitching prefers the later window's complete boundary rendering; the
measured worst case is now 0.0392 at all three tolerances, down from 0.0588.
No sweep position has a deletion; the two worst-case errors are one substitution
and one insertion.

## Milestone 3C acceptance check

This check uses the already-downloaded VAD and Parakeet models:

1. Disconnect the Mac from the network.
2. Select a downloaded Parakeet model and start recording.
3. Speak briefly, pause for at least one second, and confirm a final **You**
   row appears.
4. Play system speech and confirm final **Others** rows use the system track's
   timeline offset.
5. Speak continuously past one selected-model window plus overlap. Confirm a
   **Partial** row appears and is replaced by a **Final** row after silence or
   the engine-aware ceiling, without duplicated overlap text.
6. Stop while ASR has queued work. Confirm the UI reports disk buffering or
   catch-up, then completion, while both WAVs remain valid.
7. Run `swift test`; `LiveTranscriptionPipelineTests` covers partial
   replacement, seam removal, attribution failure, backpressure hysteresis,
   full transport/VAD/spool/ASR integration, and the virtual one-hour
   two-source bounded-window soak.

## Milestone 5B Phase B acceptance check

1. Start a recording and confirm the notes surface and transcript rail replace
   the setup view without adding a header above the notes.
2. Type Markdown syntax continuously. Confirm the syntax is highlighted while
   the plain text appears immediately in the session's `notes.md`.
3. Resize and collapse the transcript rail, reopen it, and confirm its width is
   retained. The notes surface has no floating control or reserved bottom
   gutter.
4. Confirm **You** and **Others** meters react to Silero speech probability even
   before a transcript row exists or when live transcription is unavailable.
5. With Parakeet selected, confirm the first-result estimate is derived from its
   14-second window plus overlap. With Whisper selected, confirm the estimate
   reflects its 30-second window plus overlap.
6. Watch a partial row become final. Its position must remain stable, and only
   the rewritten tail receives the brief completion highlight.
7. Exercise missing-model, model-load failure, missing-Silero, buffering,
   catching-up, silent-system-track, and system-audio-preparing states. Every
   transcription failure must say that recording is unaffected. Preparing,
   buffering, catching up, and silence belong in the sidebar; missing or failed
   transcription dependencies belong in the transcript rail.
8. Verify VoiceOver labels and dark appearance for the panes, rail controls,
   elapsed time, level meters, status, and stop control.
9. While recording, press Command-Shift-K with Scribe focused and again while
   another app is focused. Each press must briefly show **Pin added at 00:00**
   with the real time. Stop, open `session.json`, and confirm both pins have
   nonnegative canonical `sampleOffset` values; `label` may be absent until a
   label is added later.
10. Stop recording and confirm Command-Shift-K is released for other apps. If
    another app already owns it, Scribe must report that the shortcut could not
    register while recording continues normally.
11. Type continuously while transcript rows are arriving. Notes must remain
    immediate because paragraph presentation is recomputed only when live rows
    change, not when the notes editor redraws.
12. Record with nothing playing through the Mac so `system.wav` remains a
    44-byte header and its track offset remains unavailable. Add several pins,
    including one immediately before Stop. Confirm every pin and the microphone
    offset survive reconciliation in `session.json`; the empty system track is
    valid. A pin confirmation must appear only after its manifest write, while
    a failed write must show the failure in the sidebar.

The recording rail is content-driven. It does not use an engine block as a
layout unit: live rows around 26–30 seconds and batch-shaped rows around 12–13
seconds wrap naturally and pass through the same paragraphing rules.

## Milestone 5B Phase A acceptance check

1. Launch Scribe and confirm the sidebar remains present while the detail pane
   switches. Collapse and restore it with the standard sidebar toggle, relaunch,
   and confirm visibility and the selected destination persist.
2. Confirm **All sessions** and **Imported** counts match the actual session
   manifests. **Needs summary** remains hidden until summary generation is
   available in Milestone 6; no unactionable smart category is present.
3. Create a manual folder. Confirm the same directory appears at the root of
   the configured Scribe save location in Finder. A session folder moved into
   it must remain indexed by its embedded UUID.
4. Use the **New recording** split control. Its main action starts capture; its
   chevron exposes **Import audio or video…**, and Command-O remains available.
5. During capture, confirm the split control is replaced in place by the red
   state indicator, elapsed time, You/Others meters, and Stop. Switch to any
   other sidebar destination: capture and both meters must continue, and
   **Current recording** must return to the recording detail.
6. Drag an audio or video file anywhere over the window. Confirm the sidebar
   shows **Drop to import** and the existing importer receives the file.
7. Press Command-K and confirm focus moves to the search field in the detail
   header. Search results themselves arrive with Phase C.
8. Inspect light, dark, Reduce Transparency, narrow sidebar limits, keyboard
   focus, and VoiceOver labels. The content pane must remain a neutral surface;
   glass belongs to sidebar controls.

## Privacy

The project contains no telemetry, analytics, crash reporter, or cloud
transcription client. Recording and inference do not use the network. The only
network paths are the user-initiated Parakeet and Silero model downloads.
