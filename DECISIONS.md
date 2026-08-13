# Technical decisions

## 2026-07-29 — Native Xcode project plus local Swift package

**Decision:** Keep an Xcode workspace and native application/framework targets,
while also exposing `AudioCapture` through a local `Package.swift` manifest for
isolated tests.

**Alternatives:** Generate the project with XcodeGen or Tuist; use only a Swift
package executable; manually add a local package product to the app project.

**Reasoning:** A native app target produces the correct macOS bundle and signing
configuration. The package manifest provides fast module tests. A project
generator would add an unapproved dependency, while a package executable is not
an adequate replacement for a macOS application target.

## 2026-07-29 — Add modules only with working behavior

**Decision:** Create `AudioCapture` in Milestone 1A and add the remaining module
targets during the milestones that first implement them.

**Alternatives:** Create empty targets for the entire final module graph.

**Reasoning:** Empty targets would be placeholders without testable behavior.
Incremental creation keeps every target meaningful while preserving the final
architecture.

## 2026-07-29 — C17 atomics for the realtime FIFO

**Decision:** Implement sample storage and atomic indices in a minimal C target,
wrapped by a small Swift API.

**Alternatives:** Add Swift Atomics; use `NSLock` or `OSAllocatedUnfairLock`;
write an unsynchronized Swift ring; rely on a newer OS-only synchronization
module.

**Reasoning:** No unapproved dependency is needed, the macOS 14.4 deployment
target is preserved, and the audio callback remains free of locks and
allocations. C11/C17 atomics provide the release/acquire semantics required by a
single-producer, single-consumer queue.

## 2026-07-29 — Backpressure starts at the ring boundary

**Decision:** A full ring accepts only the samples that fit and returns the
written count. It never overwrites unread samples.

**Alternatives:** Overwrite oldest samples; dynamically grow the buffer; block
the producer.

**Reasoning:** Growing or blocking is invalid on a realtime audio thread.
Returning a short write makes loss measurable so the session coordinator can
surface an overrun and apply later backpressure policy.

## 2026-07-29 — Stateful AVAudioConverter wrapper

**Decision:** Give each source's serial consumer one `AudioResampler` that
preserves `AVAudioConverter` state across input blocks.

**Alternatives:** Recreate or reset the converter per callback; implement a
custom sample-rate conversion filter.

**Reasoning:** Converter continuity avoids block-boundary artifacts, while
Apple's converter supplies production-quality rate conversion. Allocation and
conversion happen after the realtime ring, never inside capture callbacks.

## 2026-07-29 — Synchronize WAV headers after every append

**Decision:** Rewrite and synchronize RIFF sizes after each writer append.

**Alternatives:** Write lengths only at orderly shutdown; periodically
checkpoint; use a custom container and convert after recording.

**Reasoning:** The straightforward implementation favors recoverability. The
cost is acceptable on the non-realtime writer actor and can be measured before
considering a less frequent checkpoint interval.

## 2026-07-29 — Mix microphone channels inside the C realtime primitive

**Decision:** Add a planar-channel mix operation to the C17 ring implementation.
It averages channels, clamps the result, and writes directly into available ring
slots.

**Alternatives:** Allocate an intermediate mono buffer per callback; keep a
mutable Swift scratch array; ask `AVAudioEngine` to negotiate a mono tap format.

**Reasoning:** Hardware input can expose multiple channels and format
negotiation varies by device. Direct C mixdown has deterministic storage
behavior and keeps allocation, copy-on-write checks, and resampling outside the
audio callback.

## 2026-07-29 — Poll the ring from one high-priority consumer

**Decision:** A detached high-priority task checks the ring every five
milliseconds when idle and sends batches through one actor-isolated converter
and writer.

**Alternatives:** Signal the consumer from the realtime callback; use an
`AsyncStream`; write or resample in the callback.

**Reasoning:** Locks, continuations, stream yields, and dispatch operations can
allocate or contend. Short polling keeps the producer callback limited to
atomic ring operations. The ten-second ring absorbs ordinary scheduling jitter,
and overruns remain measurable.

## 2026-07-29 — Preserve one WAV across microphone route changes

**Decision:** On engine configuration changes or wake, stop the tap, drain old
samples, replace the resampler for the new input rate, and restart capture into
the same canonical WAV.

**Alternatives:** End the recording; silently discard buffered samples; keep the
old converter after a hardware-rate change.

**Reasoning:** The output contract remains 16 kHz mono regardless of hardware
rate. Draining before replacing the converter preserves ordering and prevents
old-rate samples from being interpreted at the new rate. Recovery failures are
surfaced and the valid portion of the WAV is finalized.

## 2026-07-29 — Represent the process tap as an AudioSubTap dictionary

**Decision:** Put a dictionary containing `kAudioSubTapUIDKey` and drift
compensation in `kAudioAggregateDeviceTapListKey`.

**Alternatives:** Put the tap UUID string directly in the tap list.

**Reasoning:** The brief uses “tap UID in the tap list” as shorthand, but the
current Core Audio header defines that list as an array of dictionaries
describing AudioSubTap objects. Encoding the dictionary matches the SDK
contract and makes drift compensation explicit.

## 2026-07-29 — Use a physical output device as aggregate clock source

**Decision:** Include the current default output device as a real subdevice and
main subdevice, while overriding its aggregate input-channel contribution to
zero.

**Alternatives:** Create a tap-only aggregate; allow input streams from a
combined input/output device into the callback.

**Reasoning:** The physical output provides the required real clock and route.
Suppressing its input channels ensures the IOProc input consists only of the
process tap, even when headphones or an interface expose microphone streams on
the same device.

## 2026-07-29 — Direct nil-queue aggregate IOProc

**Decision:** Register `AudioDeviceCreateIOProcIDWithBlock` with a `nil`
dispatch queue and feed the callback's `AudioBufferList` directly to the C17
ring mixer.

**Alternatives:** Retarget `AVAudioEngine`; supply a dispatch queue; construct
`AVAudioPCMBuffer` objects in the callback.

**Reasoning:** The SDK specifies that a nil queue invokes the block directly.
This avoids the known `AVAudioEngine` aggregate-device trap and keeps the
realtime callback free of allocation, locks, logging, conversion, and disk I/O.

## 2026-07-29 — Start microphone before the global process tap

**Superseded on 2026-08-11 by launch-time system-tap prewarming below.**

**Decision:** The dual coordinator starts microphone capture first and system
capture second.

**Alternatives:** Start in the opposite order or concurrently.

**Reasoning:** The process tap excludes Scribe by its Core Audio process object.
Starting the microphone ensures that process object exists before the tap is
created. Sequential startup also makes partial-failure cleanup deterministic.

## 2026-07-29 — Probe system-audio permission with a disposable process tap

**Decision:** Treat system-audio authorization as a last-observed state. On an
explicit first-run button press, start an all-process tap graph briefly, discard
its ring contents, and tear it down without creating a WAV.

**Alternatives:** Claim an exact preflight state; inspect the TCC database; call
private TCC framework symbols; wait until the first real recording to explain
the permission.

**Reasoning:** Unlike microphone capture, Core Audio process taps expose no
public authorization-status or request API. Apple's contract says the system
prompts when recording starts from an aggregate that contains a tap. The
disposable graph exercises that public path without retaining audio. Persisting
only the observed result makes the UI useful across launches without
misrepresenting it as a live TCC query.

## 2026-07-29 — Deep-link to the audio-only privacy route

**Decision:** Use the `Privacy_AudioCapture` System Settings route for system
audio and `Privacy_Microphone` for microphone access.

**Alternatives:** Link system audio to `Privacy_ScreenCapture`; open only the
top-level Privacy & Security pane.

**Reasoning:** The installed macOS privacy extension defines separate
AudioCapture and ScreenCapture routes. Scribe uses a process tap and requests
only system audio, so the audio-only route is the narrow, accurate destination.

## 2026-07-30 — Persist monotonic per-track offsets beside the WAV files

**Decision:** Write a small versioned `capture-session.json` containing the
microphone and system WAV paths plus each track's offset from a shared
`ContinuousClock` origin. Measure the offset between the successful completion
of microphone and system activation.

**Alternatives:** Treat both WAV files as starting at zero; use wall-clock
dates; add a database before the Persistence milestone; pad one file with
estimated silence.

**Reasoning:** Sequential startup is required for reliable self-exclusion, so
assuming both sources start together would misorder early transcript results.
A monotonic offset is immune to wall-clock adjustments and keeps the recording
self-describing without prematurely introducing the database layer. If the
manifest cannot be written, both capture services are stopped and finalized.

## 2026-08-11 — Prewarm an unstarted system tap at launch

**Decision:** Prepare the self-excluding process tap, private aggregate device,
and registered IOProc concurrently with app initialization, but do not call
`AudioDeviceStart` until the user records. Keep the IOProc's atomic realtime
routing slot empty while idle; allocate and attach the 7.32 MiB ring,
first-sample latch, consumer, and WAV writer only at Record. After a clean stop,
detach those recording resources and retain the unstarted graph. Fully discard
the graph before sleep, on default-output or format change, aggregate death,
and after a Core Audio service restart; rebuild on wake or route recovery.

**Alternatives:** Pay graph preparation after Record; start the prepared device
at launch; allocate the full recording pipeline while idle; keep graph objects
across sleep and route changes.

**Reasoning:** On real macOS 26 hardware, IOProc registration measured
13,725.23 ms cold and about 2 ms warm in the original stage sweep. A dedicated
privacy run then measured 2,134.54 ms for the process's first registration and
6.16 ms for a second registration on the same unstarted aggregate, showing that
the delay belongs to first registration rather than every IOProc. During a
90-second hold with audible YouTube playback, both IOProcs delivered zero
callbacks, macOS showed no purple indicator, and Control Center listed no Scribe
capture. Preparation added about 1 MB to app RSS; `coreaudiod` counters were not
readable from the app. The app reported 39 package-idle and 1,440 interrupt
wakeups during the UI-driven hold, an upper bound that includes the countdown
and cannot be attributed solely to the unstarted graph. The diagnostic confirmed
that neither the ring nor writer was allocated. Prewarming therefore converts
variable Core Audio initialization into launch work without recording early,
showing a privacy indicator, or retaining recording-sized idle memory.

## 2026-07-30 — Bound batch input to 14-second canonical chunks

**Decision:** Read each WAV through an actor-owned `AVAudioFile` and allocate at
most 14 seconds of Float32 samples per chunk by default.

**Alternatives:** Load both complete WAVs into arrays; make the engine protocol
file-URL-specific; implement VAD and overlapping windows during batch
foundation work.

**Reasoning:** The approved engine protocol accepts sample arrays, but a
one-hour two-track meeting should not require both full recordings in memory.
Fourteen seconds fits the intended Parakeet batch window. VAD, overlap, and
de-duplication remain a separate Milestone 3 concern.

## 2026-07-30 — Make engine cleanup a batch-pipeline invariant

**Decision:** `BatchTranscriptionPipeline` calls `unload()` after success,
preparation failure, transcription failure, validation failure, or
`finish()` failure.

**Alternatives:** Let each caller manage model lifetime; unload only after
successful transcription.

**Reasoning:** Large Core ML models must not remain resident after a failed
session. Central lifecycle ownership is deterministic and mock-testable, while
the engine abstraction remains independent of UI and model implementation.

## 2026-07-30 — Pin FluidAudio exactly at 0.15.5

**Decision:** Use FluidAudio `0.15.5` with an exact Swift Package Manager
requirement in both the package manifest and Xcode project.

**Alternatives:** Track a branch; use a compatible minor-version range; copy
FluidAudio source into the project; implement Parakeet Core ML orchestration
directly.

**Reasoning:** FluidAudio is an approved dependency and supplies the tested
Parakeet model registry, compilation, TDT decoder, token timing, and Apple
Silicon Core ML path. An exact pin protects the strict-concurrency build and
offline contract from an unreviewed package update.

## 2026-07-30 — Separate explicit acquisition from offline preparation

**Decision:** Give model download and inference different entry points.
The explicit install/resume methods on `FluidAudioModelManager` are the only
operations that permit network access. `ParakeetTranscriptionEngine.prepare`
requires a complete cache, enables FluidAudio offline mode, and only then loads
models.

**Alternatives:** Call FluidAudio's combined `downloadAndLoad` from
`prepare()`; automatically download the selected model on first transcription;
ship models inside the application bundle.

**Reasoning:** Combined loading can make a missing or damaged artifact trigger
network access at an unexpected time. A separate Download Model action makes
the one network operation visible, keeps recording and transcription
independently usable offline, and produces an actionable missing-model state.
Bundling both 0.6B models would make the application impractically large.

## 2026-07-30 — Map one Parakeet result per fixed batch chunk

**Decision:** Aggregate FluidAudio token timings into words, shift their
chunk-local times onto the capture-session timeline, and emit one nonempty
segment per 14-second chunk.

**Alternatives:** Infer sentence boundaries from punctuation now; discard word
timings; expose FluidAudio result types directly; implement overlapping
VAD-aware segments during batch work.

**Reasoning:** The mapping preserves precise source and word timing without
coupling the public engine contract to FluidAudio. Punctuation-only splitting
would be unreliable across 25 languages. Fixed batch segments meet Milestone 2
and keep VAD, overlap, and seam de-duplication scoped to Milestone 3.

## 2026-07-30 — Commit canonical audio before live fan-out

**Decision:** Emit each source-indexed `CanonicalAudioBlock` only after the
matching samples have been appended and synchronized in its WAV.

**Alternatives:** Fan out directly from the realtime callback; send the block
before WAV persistence; make live-pipeline success a requirement for recording.

**Reasoning:** The realtime callbacks keep their existing allocation-free,
lock-free contract. WAV-first ordering makes the durable track authoritative
and ensures a failed live stage cannot corrupt or abort an otherwise valid
recording.

## 2026-07-30 — Use per-source append-only files for live backpressure

**Decision:** Give the shared `LiveAudioTransport` actor one sequential spool
file per source, with source-relative sample indices and hysteretic backlog
states. Retain only counters and the block currently crossing the actor.

**Alternatives:** Grow an in-memory array or `AsyncStream` buffer; discard old
speech; block the realtime producer; switch models before a VAD/ASR consumer
exists.

**Reasoning:** Disk capacity, rather than RAM, absorbs ASR stalls without
dropping captured speech. Separate files preserve source ordering for per-source
VAD. A ten-second high threshold and two-second recovery threshold avoid UI
state flapping. Milestone 3C later chose to preserve the explicitly selected
model rather than use silent fallback; disk spooling provides the safe behavior
independently of a particular engine.

## 2026-07-30 — Keep the Milestone 3A spool transient

**Decision:** Remove `LiveSpool` on orderly stop or failed startup while keeping
the synchronized WAV files as the recording of record.

**Alternatives:** Persist both formats indefinitely; treat the live spool as
crash-recovery storage; delete the spool only on next launch.

**Reasoning:** Before VAD and live ASR consume these records, retaining a second
complete audio copy would waste disk and complicate data retention. The
recoverable WAV already owns durability. Later submilestones can evolve spool
recovery atomically if finalized live transcript segments require it.

## 2026-07-30 — Separate Silero acquisition from offline VAD loading

**Decision:** Install Silero only from an explicit **Download Live VAD**
action. During recording, require the compiled local bundle, enable FluidAudio
offline mode, load it manually with `MLModel`, and inject it into
`VadManager`.

**Alternatives:** Use FluidAudio's convenience VAD initializer; download
automatically when recording begins; bundle the model in the application.

**Reasoning:** The convenience path can acquire a missing model. Manual loading
keeps the recording path offline and makes missing-model behavior predictable.
Recording remains useful without VAD because the independently synchronized
WAV files continue as the source of truth.

## 2026-07-30 — Use independent recurrent VAD state and hard segmentation limits

**Decision:** Give microphone and system audio separate Silero recurrent state,
apply 0.85/0.70 entry/exit hysteresis, and finalize continuous speech at an
exact 30-second sample boundary.

**Alternatives:** Share detector state across tracks; use a single probability
threshold; wait indefinitely for silence; concatenate both sources before VAD.

**Reasoning:** Shared state would leak one source's acoustic history into the
other. Hysteresis avoids boundary flapping, while a sample-count ceiling
guarantees bounded inference units during uninterrupted speech.

## 2026-07-30 — Spool overlapping speech windows and de-duplicate by source

**Decision:** Emit 14-second windows stepped by 12.5 seconds, serialize them
per source, and remove the longest matching transcript seam only between
timeline-adjacent results from that same source.

**Alternatives:** Keep windows in an unbounded array; omit overlap; compare
across sources; remove a fixed number of words.

**Reasoning:** A 1.5-second overlap protects words at model boundaries.
Disk-backed output preserves bounded memory until live ASR catches up.
Source-aware longest-boundary matching removes repeated text without merging
independent speakers or assuming a fixed speech rate.

## 2026-07-30 — Represent live text as replaceable segment rows

**Decision:** Use one stable row identity per source and VAD speech-segment
index. Overlapping nonfinal windows extend that row, and its final window
replaces the row with a finalized value.

**Alternatives:** Append every window result; mutate arbitrary SwiftUI array
indices; wait for all speech to finish before showing any text.

**Reasoning:** Stable identity gives SwiftUI a small deterministic update,
makes the partial-to-final transition visible, and prevents overlap windows
from appearing as duplicate rows. The source plus segment index remains unique
without introducing persistence identifiers before Milestone 5.

## 2026-07-30 — Buffer live ASR lag to disk without silent model fallback

**Decision:** Consume the selected Parakeet model for the entire session. When
three or more VAD windows are pending, expose **buffering to disk**, then
**catching up** until one remains.

**Alternatives:** Grow an in-memory queue; drop speech; automatically replace
the selected model with Parakeet v2; block audio capture.

**Reasoning:** The existing per-source window spool already provides bounded
memory and preserves every speech sample. Silently changing models would alter
language support and accuracy, contradicting explicit model selection.
Recording remains authoritative and continues independently if live ASR fails.

## 2026-07-30 — Gate append-only spool reads with pending counts

**Decision:** Track complete pending records per source inside each transport
actor and call the corresponding file reader only when that count is nonzero.
Treat a missing record after a positive count as malformed storage.

**Alternatives:** Repeatedly probe an empty append-only `FileHandle`; reopen or
seek the file on every poll; delay consumer startup until capture has produced
data.

**Reasoning:** Production consumers start before the first capture block and
poll concurrently with writers. Avoiding empty reads prevents a reader from
remaining at a stale end-of-file position, while the actor-owned count provides
a deterministic availability check without extra filesystem work.

## 2026-08-01 — Evaluate EOU as an optional live capability, not a replacement

**Decision:** Keep FluidAudio pinned to `0.15.5` and retain the existing
Silero/window/TDT path. Treat Parakeet Realtime EOU as a possible future
English-only low-latency live-preview capability behind a refined streaming
engine protocol.

**Alternatives:** Upgrade FluidAudio before evaluation; replace Milestone 3B
globally; force the cache-aware streaming model through the existing bounded
request/response method; reject streaming entirely.

**Reasoning:** The pinned release already contains the EOU streaming API, so an
upgrade adds no capability today. EOU can reduce partial latency and eliminate
Silero/window segmentation for its own path, but it supports only English and
does not emit punctuation or capitalization. TDT v3 remains necessary for the
required multilingual coverage and higher-quality durable transcript text.
Whisper and other window-based engines also continue to need a segmentation and
backpressure path.

## 2026-08-01 — Commit a synthetic ASR regression fixture

**Decision:** Commit a 19.6-second Samantha-voice fixture generated by macOS
`say`, converted to canonical 16 kHz mono Float32 WAV, together with its source
text. Run it in the ordinary suite whenever the chosen Parakeet model is already
installed, and keep real recorded audio as a separate opt-in fixture.

**Alternatives:** Require environment-provided audio for every golden run;
commit real speech without a clear redistribution grant; let tests download a
model; replace real-model testing entirely with a mock.

**Reasoning:** A committed deterministic fixture turns the real adapter into a
repeatable regression guard without network activity or licensing ambiguity.
Skipping names the exact missing local model. Synthetic speech cannot represent
room noise, accents, disfluency, or meeting cross-talk, so it is not presented
as an accuracy benchmark and the optional recorded fixture remains available.

## 2026-08-01 — Let each transcription engine own window geometry

**Decision:** Add `preferredWindowDuration` and `preferredOverlap` to the
transcription-engine contract. Batch WAV reads and live VAD windowing resolve
their geometry from the selected engine; Parakeet declares 14 seconds with a
1.5-second overlap.

**Alternatives:** Keep values independently hardcoded in both pipelines; make
the UI select geometry; infer the engine type with runtime casts.

**Reasoning:** Window requirements are model capabilities. Keeping them on the
engine prevents batch and live behavior from drifting and allows a later
Whisper engine to request its required 30-second window without model-specific
conditionals in either pipeline.

## 2026-08-01 — Overlap and stitch batch transcription windows

**Decision:** Advance canonical batch reads by engine window duration minus
engine overlap, then run produced segments through the existing source-aware
overlap deduplicator before the final timeline merge.

**Alternatives:** Keep nonoverlapping batch chunks; concatenate overlapping
results verbatim; add a second batch-only text merger; load the complete track
into memory.

**Reasoning:** Context on both sides of a model boundary protects words split
by a batch seam. Reusing the timing-aware live deduplicator keeps each word once
without mixing microphone and system speech, while bounded reads preserve the
long-recording memory guarantee.

## 2026-08-01 — Bound timed utterances by their words

**Decision:** When Parakeet returns word timings, set each transcript segment's
start to the first mapped word and its end to the last mapped word. Use backend
duration from the chunk start only when no valid word timing is available.

**Alternatives:** Display the complete ASR window bounds; use backend duration
even when words identify a tighter interval; invent timing for untimed text.

**Reasoning:** Chunk bounds describe inference input, not when the utterance was
spoken. Word-derived bounds make microphone/system interleaving and visible row
timestamps reflect speech while retaining a safe fallback for sparse backend
results.

## 2026-08-01 — Materialize documented Core Audio render gaps as silence

**Decision:** When a system-tap `AudioBuffer` has a nil data pointer but a
nonzero reported byte size, append that frame count as zero-valued samples to
the canonical fan-out. Keep an actually empty, header-only system track valid.

**Alternatives:** Compress gaps out of the WAV; add per-gap corrections to the
manifest; reject an empty remote-side track; generate silence from a wall-clock
timer independently of Core Audio.

**Reasoning:** Core Audio documents nil data with retained byte size for a
disabled input stream. That byte count is the render timeline information the
old mixer discarded. Materializing it before WAV/live fan-out preserves one
linear sample-index mapping for persistence, VAD, and transcription without a
second timing model. A timer would race the device clock, while manifest gap
records would leave the durable audio itself temporally compressed.

## 2026-08-01 — Order equal transcript starts by capture source

**Decision:** Sort transcript segments first by absolute start, then microphone
before system, then by end and text. Reuse the same comparator for live rows and
batch timeline merges; continue applying each track's manifest start offset
before sorting.

**Alternatives:** Compare end time before source; rely on insertion or dictionary
order; sort by the displayed whole-second timestamp; always put the shortest
utterance first.

**Reasoning:** The microphone capture starts first and the system track carries
its measured positive offset. At a genuinely equal absolute start, source order
is the stable tie-breaker; utterance length must not reverse the speaker order.
Comparing full-precision times avoids manufacturing ties from UI rounding.

## 2026-08-01 — Carry the observed unavailable component into status text

**Decision:** Give live-transcription's unavailable state an explicit reason:
missing Silero voice-activity model or missing Parakeet transcription model.
Centralize live transport, speech, and transcription wording in a tested
formatter.

**Alternatives:** Infer the reason from whichever model is usually missing;
keep one generic unavailable message; let each view independently reconstruct
pipeline state.

**Reasoning:** The previous shared state blamed Parakeet even when the branch
had directly observed missing Silero. The audit found one related issue: raw
live-audio transport buffering was labelled an ASR backlog even though it can
occur before ASR. It also found idle batch status claiming readiness without a
recording or selected model. Explicit inputs ensure messages report observed
state rather than a plausible cause and keep degradation understandable.

## 2026-08-01 — Quantize only durable session audio to Int16 PCM

**Decision:** Keep capture, live fan-out, VAD, and transcription in Float32,
but stream each durable 16 kHz mono session track as signed 16-bit PCM. Continue
accepting both Int16 PCM and the legacy Float32 format in the transcription
reader.

**Alternatives:** Retain Float32 WAV storage; quantize inside realtime capture;
convert old sessions in place; introduce a compressed-audio dependency.

**Reasoning:** Int16 halves the durable sample payload without changing model
input or realtime behavior. Quantizing on the existing non-realtime consumer
preserves callback safety. Read-time compatibility keeps existing recordings
usable and avoids modifying user session data.

## 2026-08-01 — Reserve disk capacity before and during recording

**Decision:** Before either audio service starts, require enough free capacity
for a configurable expected duration plus a configurable reserve. Estimate the
two Int16 WAVs and worst-case simultaneous Float32 live-transport and speech
window spools. Recheck periodically during recording and, at or below the
reserve—or if capacity can no longer be queried—stop through the ordinary
two-track finalization path.

**Alternatives:** Check only when a file write fails; budget only durable WAVs;
monitor in the UI; delete prior sessions automatically; continue recording when
the capacity provider fails.

**Reasoning:** Write failure is too late to guarantee valid headers, while the
temporary bounded-memory queues can dominate disk use under sustained backlog.
Keeping policy and monitoring in the capture coordinator guarantees preflight
before capture, applies equally outside the UI, and is deterministic under an
injected provider. Automatic deletion would violate local-data ownership.

## 2026-08-03 — Establish a dependency-free model catalogue boundary

**Decision:** Add a `ModelManager` framework that owns validated model
identifiers, provider/task metadata, language coverage, safe installation folder
names, live-processing capability, and transcription window geometry. Seed it
with the two current Parakeet variants and Silero before migrating storage or
download behavior.

**Alternatives:** Keep extending milestone-specific stores in `SpeechPipeline`;
introduce the framework only when WhisperKit is added; make catalogue entries
unvalidated dictionaries; add speculative Whisper entries immediately.

**Reasoning:** A dependency-free catalogue prevents the future Whisper package
from becoming the owner of application-wide identity and policy. Validating
identifiers, paths, and geometry at construction catches unsafe or contradictory
metadata before it reaches storage or inference. Starting with models Scribe
already supports keeps the first checkpoint factual; Whisper entries wait for
measured source metadata and the exact dependency pin.

## 2026-08-03 — Centralize model paths without relocating caches

**Decision:** Make `ModelStoragePaths` the single owner of Scribe's
`Application Support/Scribe/Models` layout and per-descriptor installation and
staging directories. Route the existing Parakeet and Silero stores through it
while preserving injected test roots and provider cache contents in place.

**Alternatives:** Move existing caches into a new Milestone 4 hierarchy; let
each adapter append `Scribe/Models` independently; centralize paths only after
the download manager exists; scan multiple legacy locations at runtime.

**Reasoning:** The current cache locations already contain large, valid models.
A path abstraction should eliminate duplication without creating a migration
or risking offline availability. Descriptor-validated single-component folder
names keep installations beneath the models root, and injected roots retain
deterministic tests without reading or writing the user's model cache.

## 2026-08-03 — Separate acquisition policy from provider transport

**Decision:** Put download state, pause/resume tokens, cancellation cleanup,
staging, streamed SHA-256 and byte-count verification, and final promotion in a
provider-neutral `ModelDownloadController`. Require provider adapters to conform
to `ModelDownloadTransport` rather than importing their SDKs into ModelManager.

**Alternatives:** Let FluidAudio and WhisperKit each own UI state and final
paths; download directly into the installed directory; hash complete artifacts
in memory; treat HTTPS completion or cache shape as sufficient integrity; keep
paused tasks alive without explicit resume data.

**Reasoning:** One state machine gives the UI truthful lifecycle semantics and
prevents partially written models from appearing available. Chunked verification
scales to large weights, while exact sizes and hashes detect truncation and
corruption. Transport injection makes pause, resume, cancel, and failure paths
deterministic without network access. Symlink containment ensures a manifest
cannot redirect verification outside its staged installation.

## 2026-08-03 — Fail closed on unknown model resource requirements

**Decision:** Measure installed logical and allocated bytes from the real model
tree without following symbolic links. Require every operational resource
profile to carry positive download, installed, and peak-RAM values backed by a
local measurement or primary upstream source. Return a denied evaluation when
requirements or current capacity are unavailable, and retain configurable disk
and RAM reserves for callers that preflight acquisition or loading.

**Alternatives:** Estimate storage and memory from parameter count; assume an
unknown model fits; count only expected manifest artifacts; follow symbolic
links during recursive accounting; rely on eventual filesystem or allocation
failure.

**Reasoning:** Quantization, compiled Core ML assets, tokenizer files, framework
overhead, and provider caching make parameter count an unreliable operational
measure. Measuring the installation captures real disk use, while cited model
profiles make preflight decisions auditable. Failing closed prevents a large
download or model load from exhausting the Mac when the manager cannot prove it
fits.

## 2026-08-03 — Put FluidAudio models behind the shared registry

**Decision:** Replace the separate Parakeet and Silero stores with one
`FluidAudioModelManager` provider adapter backed by `ManagedModelRegistry`.
Resolve exact artifact sizes and SHA-256 values from the official Hugging Face
tree before each new transfer, using LFS digests directly and hashing only small
non-LFS metadata. Download into the manager's staging directory, validate the
provider cache shape there, run the shared checksum pass, and only then promote
the directory. Implement FluidAudio pause/resume at file granularity: cancel the
active request, retain complete staged files, and let resume skip those files.

FluidAudio 0.15.5's Parakeet path argument is nominal: it derives the real cache
folder from the selected repository and removes the `-coreml` suffix. Make that
real folder (`parakeet-tdt-0.6b-v3` or `-v2`) canonical in the catalogue. Do not
move or copy the existing cache.

**Alternatives:** Keep two provider-specific stores; bypass the general
download controller for FluidAudio; embed a large manifest that becomes stale
when the upstream repository changes; trust file presence without checksums;
rename or relocate the existing cache; claim byte-level resume that FluidAudio
0.15.5 does not expose.

**Reasoning:** A single provider adapter makes the general lifecycle real before
WhisperKit arrives, while the dependency-free manager remains reusable. Reading
primary repository metadata avoids invented sizes and lets an upstream change
fail safely if it races a transfer. Correcting the catalogue to the folder
FluidAudio actually reads makes disk accounting truthful and was verified by
the committed offline Parakeet golden test against the already-installed model.

## 2026-08-03 — Pin the renamed Argmax SDK at WhisperKit 1.0.0

**Decision:** Add `argmaxinc/argmax-oss-swift` at the exact stable version
`1.0.0` and link only its `WhisperKit` product to SpeechPipeline. Keep
FluidAudio independently pinned at exactly `0.15.5`. Resolve and commit the
package lockfile, including WhisperKit's `swift-argument-parser` transitive pin,
without initializing WhisperKit or downloading model weights.

**Alternatives:** Continue from the pre-rename `WhisperKit` repository and a
`0.x` tag; use a version range; link the `ArgmaxOSS` umbrella product; track a
branch or revision; let the first inference path add the package implicitly.

**Reasoning:** Argmax identifies 1.0.0 as the stable rename release and exposes
WhisperKit as an individual library product with Swift 6 support. An exact pin
makes builds reproducible and keeps unused SpeakerKit and TTSKit APIs out of
Scribe's dependency boundary. Package resolution acquires source only; the
model manager remains the sole authority for explicit model downloads.

## 2026-08-03 — Support only Whisper variants with direct fixture evidence

**Decision:** Add twelve explicit Whisper entries backed by Argmax's official
[`whisperkit-coreml`](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main)
artifact folders: standard Tiny, Tiny English, Base, Small, Medium, Large v3,
OpenAI's 2024 Large v3 Turbo architecture, Distil Large v3, and four named
compressed/Argmax-optimized Large or Distil variants. Give every entry exact
30-second/1.5-second geometry, its own committed WER ceiling, verified installed
bytes, and a measured conservative first-load process peak RSS. Use parameter
counts only as descriptive UI metadata, sourced from the official
[OpenAI Whisper](https://huggingface.co/openai/whisper-large-v3) and
[Distil-Whisper](https://huggingface.co/distil-whisper/distil-large-v3)
model cards, never for storage or RAM safety.

Require `WhisperKitModelManager` to resolve and stage exact files, add the
matching OpenAI tokenizer locally, verify sizes and SHA-256 values, and promote
only complete installations. Regular Git files up to the Hub tooling's 10 MiB
large-file boundary are hashed directly; larger weights require upstream LFS
SHA-256 metadata. Construct WhisperKit with download disabled. Validate the
local tokenizer before loading, but let `loadModels()` assign it so WhisperKit
first detects vocabulary/encoder shape and multilingual state. A missing or
failed selection names that exact model and never falls back to another.

**Alternatives:** Expose the entire upstream folder list without testing; call
WhisperKit's automatic download/model recommendation path; substitute a smaller
model after load failure; estimate resources from parameter count; treat
`_turbo` as synonymous with OpenAI's Turbo architecture; preassign a tokenizer
before model loading; keep the compressed 216 MB Small diagnostic as the
standard Small entry.

**Reasoning:** The milestone contract says an entry without a WER is not
supported. Direct measurements make every current entry auditable and allow the
resource evaluator to fail closed. Argmax folder suffixes describe distinct
properties: `_*MB` denotes compressed weights, while `_turbo` can denote an
Argmax streaming optimization rather than OpenAI's Turbo architecture. The
load-order rule was established by a real defect: preassigning the tokenizer
skipped WhisperKit's model-shape detection and returned empty Small transcripts;
letting the pinned SDK complete its detection produced WER 0.0000 with word
timestamps. Synthetic clean speech remains a regression guard, not a claim of
real-meeting accuracy.

## 2026-08-03 — Serialize all prepared ASR engines behind one resident lease

**Decision:** Add a SpeechPipeline actor that owns at most one prepared
`TranscriptionEngine`, and a facade that retains the existing engine contract.
Every activation unloads the previous exact engine before preparing the next.
Generation-stamped leases invalidate old facades after a switch; stale unloads
are harmless and stale inference names the requested and resident identifiers.
Reject a switch while inference is in flight, and let unload wait for the active
call before releasing Core ML resources. Preserve the selected engine's original
prepare failure and leave no resident engine after a failed replacement.

**Alternatives:** Let each screen/pipeline own and prepare its engine directly;
keep Parakeet and Whisper resident together; rely on UI selection locking alone;
unload an engine concurrently with inference; restore the previous model after a
replacement fails; cache several prepared engines based on guessed RAM cost.

**Reasoning:** A 24 GB Mac can run the measured variants individually, but
simultaneous Core ML residency makes peak memory and lifecycle behavior opaque.
The coordinator enforces the invariant below the model UI and remains testable
with engine mocks. Explicit rejection during an active call prevents use-after-
unload races, while invalid leases ensure delayed pipeline cleanup can never
unload a newer selection.

## 2026-08-03 — Drive model controls from exact catalogue selections

**Decision:** Replace the Parakeet-only picker and separate VAD download control
with one catalogue-driven model card. Persist one exact transcription selection
as the default, capture it for live or batch work, and route both providers
through the resident coordinator. Show provider, language, quantization, speed,
measured disk/RAM, live safety evaluation, per-model status, and actual total
library usage. Expose install, pause, resume, cancel, and confirmed deletion.
Offer the closest smaller installed measured model after an unavailable or
failed exact selection, but require the user to click the offer.

**Alternatives:** Keep separate provider screens; list only three representative
Whisper sizes; silently choose a smaller model; infer UI metadata outside the
catalogue; hide staged-download controls; delete a whole provider cache; retain
the milestone-specific Silero action in the capture card.

**Reasoning:** One exact selection prevents UI/provider drift and preserves the
no-substitution contract already enforced by adapters. Explicit fallback keeps
recording recoverable without misrepresenting which model produced text. Shared
manager state makes storage and safety figures auditable, while scoped confirmed
deletion cannot affect another model or any session recording.

## 2026-08-11 — Let forced live continuations correct the finalized overlap tail

**Decision:** When continuous speech reaches its engine-aware hard ceiling,
carry the selected engine's overlap into the first window of the continuation
segment. Keep a separate speech-segment and row identity, but retain the prior
final seam per source. When the continuation's first timed result arrives,
prefer that later rendering: replace only the preceding finalized row's
overlapping tail and keep the continuation text. Preserve the preceding row's
stable ID and final state, so the live view updates it in place without removing
or reordering the row. Treat **Final** as “all audio for this row has arrived,”
not as a guarantee that its overlap tail can never be corrected. Batch output
has no display-stability constraint and should likewise prefer the later
window's more complete boundary context.

**Alternatives:** Keep the earlier finalized rendering and never rewrite the
live view; select between windows by reported confidence; merge every
ceiling-forced continuation into one unbounded speech segment and row.

**Reasoning:** The earlier window ends at an arbitrary sample boundary and can
decode a split word as corrupted fragments. The continuation has overlap before
that boundary and is systematically the better rendering. Keeping the earlier
text makes corruption permanent. Confidence is not a reliable common policy:
Whisper exposes per-word probabilities, while the Parakeet adapter currently
repeats segment confidence on its words, and scores from independent windows
are not necessarily calibrated. A narrowly bounded, one-time correction gives
Milestone 5 better transcript text while stable row identity limits the visual
cost to the last few words changing in place.

Batch stitching now applies that same later-window preference. The reconciler
keeps an earlier-window word only when its full timed span ends before the
replacement threshold, rather than testing its start as if the word were a
point. This prevents a seam-straddling rendering from surviving alongside the
later complete rendering. The 17-position Parakeet seam sweep improved from the
previous 0.0588 worst case to 0.0392 at 125, 250, and 500 ms. No position lost a
word; the worst result contains one substitution and one insertion.

## 2026-08-11 — Remove the unused live-processing catalogue flag

**Decision:** Remove `supportsLiveProcessing` from `ModelDescriptor`. Keep the
current model picker behavior: every transcription model with valid window
geometry remains eligible for windowed live transcription, subject to local
installation and memory safety. Keep `supportsStreaming` on the engine as the
runtime distinction; neither Parakeet nor Whisper currently streams.

**Alternatives:** Mark slow or large Whisper variants ineligible for live use;
derive eligibility dynamically from measured latency and the current Mac;
introduce separate live and durable-transcript model pickers.

**Reasoning:** The deleted flag was uniformly true, included Silero VAD, and no
code read it. A static boolean cannot express the actual tradeoff: Large v3 is
window-capable but has high first-partial latency and memory cost. Preserving
selection avoids an unrequested product restriction, while the model card now
discloses Large v3's measured live latency. A separate live-model policy remains
an explicit future product decision rather than misleading catalogue metadata.

## 2026-08-11 — Surface and safely remove unrecognized model folders

**Decision:** Scan direct child folders under the canonical Models directory,
excluding catalogue installation names and the managed `.Downloads` staging
area. Recursively report each unrecognized folder's logical size and file count,
include it in total local-model disk usage, and expose an individually confirmed
move-to-Trash action. Revalidate the folder name, parent, catalogue status,
directory type, and non-symlink status immediately before removal. Use the same
macOS Trash operation for catalogue-managed transcription models and Silero VAD;
never unlink a user-visible model folder directly.

**Alternatives:** Count only catalogue entries; silently delete failed or old
downloads; expose the whole Models directory in Finder and leave cleanup manual.

**Reasoning:** Provider evaluation and catalogue changes can leave substantial
data that ordinary model controls cannot see. Permanent deletion risks removing
user-placed or diagnostically useful data without recovery, and a large model
should not be less recoverable than a session recording. An explicit orphan
card makes disk accounting truthful while keeping removal scoped to one reviewed
folder and away from known models, active staging, recordings, and transcripts.
Moving the intact folder to Trash preserves the normal macOS recovery path.

## 2026-08-11 — Normalize timed words before deriving text geometry

**Decision:** Order every consumed timed-word array by absolute start time and
then end time. Normalize in both engine adapters, both overlap strategies, and
live row assembly. Derive timed segment and live-row bounds from the ordered
first and last words. Keep validation of individual finite ranges unchanged.

**Alternatives:** Trust provider order; sort only in the ceiling reconciliation;
reject unordered output instead of accepting and normalizing it.

**Reasoning:** Provider order is customary but was not an enforced contract.
Array position previously could invert engine segment bounds, return a trimmed
overlap remainder in the wrong order with clipped bounds, and assign a live row
a late start that changed transcript ordering and seek position. Normalization
at every consumption boundary makes the invariant explicit and protects mock,
provider, and future-engine output alike. Existing Scribe sessions contain WAVs
and capture manifests, not persisted transcript rows, so no stored transcript
migration or re-derivation is required.

## 2026-08-11 — Make macOS 26 the deployment baseline

**Decision:** Raise both Swift Package Manager and Xcode deployment targets from
macOS 14.4 to macOS 26.0 before beginning the session-store work. Keep the
existing capture architecture unchanged: `AVAudioEngine` for microphone input
and a private Core Audio process tap, aggregate device, and direct IOProc for
system audio.

**Alternatives:** Continue supporting macOS 14.4; conditionally adopt macOS
26-only Core Audio tap properties; replace the audio-only process tap with a
ScreenCaptureKit stream.

**Reasoning:** Scribe is still pre-release, so Milestone 5A can establish one
tested OS baseline before user-visible session folders and their interface make
compatibility promises harder to change. The macOS 26 SDK leaves every API in
the verified capture chain available without deprecation or signature changes.
It adds `CATapDescription.bundleIDs` and process restoration, which help taps
that follow selected third-party processes across relaunches but do not simplify
Scribe's global mix excluding its own stable process. ScreenCaptureKit can also
deliver system audio, but it adds screen-capture authorization, shareable-content
discovery, and content-filter lifecycle to an audio-only feature. Neither
alternative is a reason to disturb the working capture path in this phase.

## 2026-08-11 — Make session folders authoritative and the database rebuildable

**Decision:** Store sessions as ordinary human-readable folders in Documents or
a security-scoped user-selected location. Put stable UUID identity and artifact
inventory in `session.json`; treat path as incidental. Use exactly GRDB 7.11.1
and FTS5 only as a rebuildable metadata and text-search index. Reconcile at
launch, activation, before recording, and after debounced FSEvents. When the
selected root is unavailable, retain indexed rows and mark them unavailable.

**Alternatives:** Keep UUID folders under Application Support; make SQLite the
source of truth; interpret a missing mount as deleted sessions.

**Reasoning:** Ordinary folders preserve local ownership and Finder workflows.
A stable embedded UUID survives rename and move. Keeping the index derivative
allows complete recovery from its deletion or corruption, while an unavailable
drive cannot accidentally trigger a mass purge.

## 2026-08-11 — Treat Finder copies as independent sessions

**Decision:** When multiple reachable folders contain the same UUID, retain the
UUID in the folder with the older creation date and atomically assign the newer
folder a fresh UUID. Index both and report the change as informational.

**Alternatives:** Report a blocking conflict; ignore the copy; merge artifacts.

**Reasoning:** Duplicating a folder is an ordinary, reasonable Finder action.
The copied audio and documents form a complete independent session. Automatic
re-identification preserves both without asking the user to understand internal
UUID conflicts or risking an incorrect merge.

## 2026-08-11 — Surface intentional additional artifacts, not filesystem noise

**Decision:** Include non-hidden regular files with common document, image,
audio, and video extensions as additional session artifacts. Ignore metadata,
hidden files, aliases, symbolic links, packages, unknown binary types,
temporary/editor/download fragments, and live transient spool directories.

**Alternatives:** Show every directory entry; show only Scribe-owned artifacts;
maintain a user-editable extension list.

**Reasoning:** A related PDF or slide deck belongs in the reading view, while
`.DS_Store`, aliases, and transient files do not represent durable session data.
An allowlist makes the behavior deterministic and avoids following links or
surfacing arbitrary executable data.

## 2026-08-11 — Derive track alignment from first captured samples

**Decision:** Replace asynchronous-start-return timing with the microphone
tap's first valid `AVAudioTime.hostTime` and the system IOProc's first valid
`inInputTime.mHostTime`. Latch each without allocation or locking, convert the
delta using `mach_timebase_info`, and store relative integer 16 kHz sample
offsets. Continue reading version-1 seconds fields as `legacyEstimated`.

**Alternatives:** Keep the startup proxy; use IOProc `inNow`; infer alignment
from final WAV lengths.

**Reasoning:** API-return time measures scheduling and setup, not when the first
stored frame was acquired. `inInputTime` is explicitly tied to the first input
frame, whereas `inNow` includes IO-thread scheduling latency. Old sessions lack
the source timestamps and therefore cannot honestly be upgraded to precise
timing.

## 2026-08-11 — Model imported media as one source with two artifacts

**Decision:** Add `.imported` as a third `AudioSource`, but restrict live
capture explicitly to microphone and system. An imported session contains one
track, preserves the original file byte-for-byte, creates canonical `audio.wav`,
and sends that one track through the existing batch pipeline. Omit participant
labels from imported transcript rows and Markdown. Decode only the first audio
track when a container carries more than one.

**Alternatives:** Pretend the file is microphone or system audio; duplicate it
into “You” and “Others”; create a separate transcript type; mix every audio
track in a multi-track video.

**Reasoning:** Source attribution describes how audio was acquired, not which
UI happens to display it. A dropped file has no defensible participant side.
Keeping the shared segment and batch types preserves all existing stitching and
export behavior without inventing identity. Choosing the first media audio track
matches ordinary AV playback and avoids silently combining language, commentary,
or alternate-program tracks.

## 2026-08-11 — Preserve a canonical-named original without collision

**Decision:** Reserve root `audio.wav` for the canonical derivative. If the
source filename itself is `audio.wav`, keep the unchanged source at
`Original/audio.wav`; retain `originalFilename=audio.wav` and list both paths as
separate artifacts.

**Alternatives:** Reuse one file as both artifacts; rename the original; rename
the canonical derivative; skip conversion when the source appears canonical.

**Reasoning:** File extensions and headers do not prove every canonical
invariant, and the work order requires both an unchanged original and a known
derivative. Two files cannot share one path. A containing directory is the only
collision resolution that preserves both required filenames and their roles.

## 2026-08-11 — Keep Phase 2 import UI disposable

**Decision:** Add the required File menu command and Command-O. Accept a file on
the placeholder window through one root `dropDestination` modifier because it
does not shape layout or session presentation. Defer the designed library drop
target and reading view to the views order; expose their required data now as
one manifest track plus original and canonical artifacts.

**Alternatives:** Build the session library and reading view in Phase 2; omit
all dropping until the views order.

**Reasoning:** The current window is scheduled for replacement. A single root
handler is trivial and reusable behavior, while designing its visible target or
artifact presentation now would create throwaway view work.

## 2026-08-13 — Make system-tap preparation single-flight and explicit

**Decision:** Route launch prewarming and recording startup through one shared
preparation task. An immediate Record request waits for an in-flight launch
prewarm; only a request that arrives before launch preparation begins can start
that same task itself. Surface the wait as a preparing UI state and persist
`systemAudioGraphPreparation` in `session.json` with `prewarmed` or
`builtAtRecordingStart`.

**Alternatives:** Keep the independent recording fallback and infer reuse from
IOProc timing; disable Record until launch prewarming finishes; build two graphs
and discard whichever finishes second.

**Reasoning:** The old fire-and-forget launch task and recording fallback raced
to reach the capture actor. A cold recording could therefore repeat the costly
IOProc registration instead of waiting. Single-flight preparation removes that
race without making the interface unresponsive, and explicit manifest data is
stable enough for users, diagnostics, and future regression tests.

## 2026-08-13 — Persist completed live transcription through the batch writer

**Decision:** On successful live-pipeline drain, require every row to be final
and pass its segments to `TranscriptArtifactWriter`. Live and batch therefore
replace the same three current exports, create the same immutable history
revision, and register the same manifest artifacts. A successful zero-row run
is still written; failed or partial output is not recorded as completed.

**Alternatives:** Keep live rows only in the view model; add a separate live
exporter; automatically run batch transcription after every live recording.

**Reasoning:** In-memory rows vanished when recording cleanup discarded the
Milestone 3 pipeline, because that pipeline predated session-folder storage.
One writer prevents the durable batch and live formats from drifting. Rejecting
partial rows avoids presenting an interrupted transcript as complete, while the
unchanged WAV tracks preserve a safe re-transcription path.

## 2026-08-13 — Keep speaker identity in session metadata

**Decision:** Store a versioned speaker registry in `session.json`, keyed by
stable string IDs and carrying source, optional display name, and whether that
name was machine- or user-assigned. Give existing one-speaker-per-source
sessions deterministic `source.<source>` identities during decode. Permit
multiple identities for one source. Rename the registry entry without modifying
audio or any transcription revision.

**Alternatives:** Put names directly in each transcript revision; infer identity
from the source label every time; restrict every source to one permanent
speaker.

**Reasoning:** A person's name should survive re-transcription and should be
editable without rewriting history. Source is an acquisition channel, not a
lasting speaker model, so an arbitrary per-source registry supports future
diarization without another manifest migration. Name provenance prevents a
later machine suggestion from silently replacing an explicit user choice.

## 2026-08-13 — Derive transcript paragraphs once from word timings

**Decision:** Use one `TranscriptParagrapher` for durable Markdown and both
Milestone 5B transcript views. Break after a sentence-ending word only when the
next word begins more than 400 ms later. Once a paragraph would exceed 45
seconds, prefer the latest sentence ending within that span; if none exists,
break at its largest word gap. Never merge across source or speaker changes. If
timings are missing or their tokens cannot reconstruct the engine text, retain
the original segment unchanged.

**Alternatives:** Paragraph each renderer independently; use VAD frame history;
show every ASR segment as a paragraph; split solely by character or time count.

**Reasoning:** The measured live transcript had sparse but meaningful word gaps,
including sentence-aligned pauses, while VAD probabilities are not retained.
One pure boundary function keeps live, reading, and exported Markdown identical.
The 45-second ceiling prevents continuous speech from becoming a wall of text,
and the passthrough rule makes formatting subordinate to exact transcript
preservation.

## 2026-08-13 — Treat ASR windows as data, not recording-view layout

**Decision:** Build the recording transcript rail from shared paragraph output,
allowing a paragraph to span consecutive live rows from the same source and
speaker. Keep row identity anchored to the first contributing live row and use
content-driven height. Derive the first-partial estimate from the selected
engine's window plus overlap. Drive recording meters from Silero probability,
not from transcript arrival.

**Alternatives:** Render one fixed-height card per ASR window; tune the view for
Parakeet's 12.5-second stride or live VAD's 26–30-second ceiling rows; animate
new final rows into replacement positions; infer speech activity from ASR text.

**Reasoning:** Engine geometry and VAD segmentation legitimately change the
transcript's shape, and re-transcription can change it again without changing
the meeting. Window-sized layout would make correct output look inconsistent.
Paragraph identity and content-driven height preserve visual continuity, while
VAD-derived meters remain responsive when ASR is loading, absent, or behind.

## 2026-08-13 — Make one shell own navigation, never capture

**Decision:** Keep a persistent `NavigationSplitView` shell around every app
state. The sidebar owns recording/import actions and the live capture control;
detail selection owns only what is rendered. Remove the floating recording
control and notes gutter. Persist sidebar visibility and destination without
persisting capture state.

**Alternatives:** Replace the whole window for recording; keep the capture
control inside the recording detail; stop capture when navigating away; open
recording and reading in separate windows.

**Reasoning:** Recording is process state, not navigation state. Keeping its
control in the persistent functional layer makes capture observable and
stoppable while the user browses, while destroying and rebuilding a detail view
cannot affect the recorder actors or their session folder.

## 2026-08-13 — Represent manual folders as real directories

**Decision:** Treat top-level directories without a session manifest as manual
folders and discover session manifests recursively beneath the save location.
Moving a session moves its complete directory; its UUID remains identity and
the index learns the new path during reconciliation. Do not traverse hidden
directories, aliases, symlinks, packages, or inside a discovered session.

**Alternatives:** Store folder labels only in SQLite; keep every session at the
root and simulate hierarchy; treat every top-level directory as a session.

**Reasoning:** Finder and Scribe must describe the same organization. A derived
database label would disappear when the index is rebuilt and would make an
ordinary Finder move look like data loss. Manifest-aware recursive discovery
preserves local ownership without confusing organizational folders with broken
sessions.

## 2026-08-13 — Store pins on the sample timeline, not UI time

**Decision:** Register Command-Shift-K as an application-global shortcut only
while capture is active. Latch the key event in mach host time and convert it to
the session timeline from the earliest real first-sample timestamp. Persist a
pin UUID, canonical sample offset, optional label, and creation date in
`session.json`. Serialize pin writes with final track-offset writes.

**Alternatives:** Derive pins from the elapsed UI clock; store seconds as a
floating-point value; leave the shortcut registered whenever Scribe runs; add a
dialog before saving; write pins to a separate sidecar.

**Reasoning:** The UI clock begins after asynchronous capture setup and is not a
sample-accurate origin. The first-sample host timestamps already define the
direction-independent two-track timeline. A recording-only Carbon hot key works
without a focused window or Accessibility permission but does not steal the
shortcut outside capture. Keeping pins in the manifest makes them durable user
data beside track timing, while serialization prevents stop and pin actions
from losing one another's metadata.

## 2026-08-13 — Gate Needs summary on capability, not count

**Decision:** Keep the Needs summary index count available, but do not render
its smart folder until summary generation exists. Resolve an old persisted
Needs summary selection to All sessions while the capability is unavailable.

**Alternatives:** Show the folder with every session before Milestone 6; hide
it only when its count equals All sessions; remove the index projection until
summary work begins.

**Reasoning:** A count comparison would make navigation appear and disappear as
session state changes. A capability gate gives the destination a stable
lifecycle and prevents an accurate but unactionable count from looking broken.
Retaining the projection avoids coupling the filesystem index migration to the
feature launch.

## 2026-08-13 — Reload session metadata inside serialized mutations

**Decision:** Route every ordinary in-place mutation—including live pins, final
track offsets, reconciled artifacts, duplicate IDs, speaker and session names,
and transcript revision history—through one manifest actor. Reload
`session.json` inside the serialized operation immediately before applying each
owned field change. Commit current transcript artifacts and their history entry
together. Treat an unavailable track timestamp as a valid `nil` offset. Show pin
success only after its atomic write returns and show write failure in the same
sidebar slot.

**Alternatives:** Serialize only pins and offsets; let the reconciler write the
manifest snapshot it scanned earlier; suppress reconciliation while recording;
infer pin success from the keypress.

**Reasoning:** Filesystem events can start reconciliation before a pin write and
finish afterward. Its old artifact-inventory update then restored a stale
manifest, erasing an already durable and confirmed pin. Header-only system WAVs
made that ordering easier to encounter but `system: nil` was not the defect.
Reload-before-mutate preserves unrelated fields regardless of which operation
entered the queue first, and post-write feedback describes durability rather
than intent.

## 2026-08-13 — Make the session library explain files, not invent state

**Decision:** Group authoritative session projections by calendar date and show
duration, source-appropriate metadata, and four semantic artifact icons. Use
FTS5 only to select sessions from notes and transcript text, then recover
segment-level timecodes from `transcript.json` for grouped hits. Rename a
session by moving its complete folder and updating its manifest title; move
deletions to macOS Trash after stating the measured folder size.

**Alternatives:** Treat the SQLite index as authoritative UI state; show flat
search rows; use filled selection backgrounds or presence dots; rename only the
manifest title; permanently unlink deleted folders.

**Reasoning:** The filesystem remains the user's durable database, and the
library should continue to make that ownership visible. Icons distinguish four
artifact meanings for low-vision users where dots do not. Grouped timed hits
keep repeated matches in one meeting intelligible. Folder and manifest names
must agree in Finder and Scribe, while Trash preserves the same recovery
guarantee already used for models.

## 2026-08-13 — Make reading independent of transcription block geometry

**Decision:** Project transcript paragraphs, playback, and artifact metadata
from timed session data rather than a presumed segment length. Use violet only
for selection and the You source, teal only for Others, and an eight-entry
appearance-adaptive speaker palette for future multi-party attribution. Put
timestamps, durations, elapsed time, and byte counts in system monospace; use
only regular and medium system weights elsewhere. Keep the animated two-source
ASCII waveform exclusive to the no-selection reader state and pause it when the
window is not key or Reduce Motion is active.

**Alternatives:** Size transcript rows around the live 30-second ceiling; merge
short batch blocks into synthetic display rows; reuse identical color literals
in dark mode; animate the empty state continuously in background windows.

**Reasoning:** The same recording legitimately changes shape when reprocessed,
so block geometry cannot be a layout contract. Timed paragraphs and a shared
session timeline preserve reading and seeking across either pipeline. Restrained
semantic color keeps source attribution legible without turning the interface
decorative, while appearance-specific colors retain contrast. Suspending the
only animation prevents an idle meeting window from consuming work.

## 2026-08-13 — Configure compatible intelligence providers behind two clients

**Decision:** Define one streamed `IntelligenceProvider` boundary, implement one
base-URL-configured OpenAI-compatible client and one Anthropic Messages client,
and express Anthropic, OpenAI, DeepSeek, Groq, Ollama, and LM Studio as presets.
Allow validated custom compatible endpoints. Keep Phase 1 independent of
session content and summary artifacts.

**Alternatives:** Implement a client per vendor; support only a fixed provider
list; add summary generation while establishing the transport layer; route
transcription through the cloud providers.

**Reasoning:** The compatible providers share request and SSE response shapes,
so vendor-specific clients would duplicate security and streaming behavior.
Custom configuration prevents a provider release from becoming an app release.
Keeping this phase content-free gives the network boundary a focused test and
review surface; transcription remains strictly local by product decision.

## 2026-08-13 — Keep provider secrets out of configuration and diagnostics

**Decision:** Store every provider key as a generic-password item in the macOS
Keychain, keyed by provider ID. Persist only endpoint metadata and selection in
UserDefaults. Resolve a credential while constructing a request, redact its
description, never log requests or response bodies, and expose only sanitized
status-based failures. Test credentials with a minimal model-list request.

**Alternatives:** Store keys beside provider presets; place keys in plist or
UserDefaults; include response bodies in failures; ask for a key on every use.

**Reasoning:** A custom provider must remain portable without making its secret
portable. Keychain provides the platform security boundary, while non-Codable
credentials and sanitized errors prevent ordinary serialization, logs, and
crash diagnostics from copying secrets. Model discovery validates the endpoint
and authorization without sending transcript content or consuming completion
tokens.

## 2026-08-13 — Keep templates outside the rebuildable session index

**Decision:** Store summary templates in a dedicated GRDB database under
Application Support. Seed six built-ins with stable IDs using insert-if-missing
semantics. Let users edit and duplicate built-ins, create and remove custom
templates, and reject unknown or malformed variables during rendering. Build
this template layer before summary generation.

**Alternatives:** Put templates in the rebuildable `sessions.sqlite`; keep them
in UserDefaults or files; overwrite built-in rows when their shipped text
changes; hardcode prompts inside Phase 2 and replace them later; silently leave
unknown placeholders in generated prompts.

**Reasoning:** Deleting the search index is a supported repair operation, so it
cannot own original user-written prompts. Stable insert-only defaults preserve
edits and still let an update add a newly shipped template. Strict substitution
makes prompt mistakes visible before any paid provider call. Implementing the
smaller durable layer first means Phase 2 has one real prompt source and avoids
a temporary generation path that would immediately be discarded.

## 2026-08-13 — Commit summaries only after a complete provider stream

**Decision:** Build Phase 2 in independently usable parts. For Part 1, render a
durable template from authoritative session files, reserve output capacity in a
provider/model context policy, and reject oversized prompts before sending.
Require confirmation for every non-loopback destination, naming the provider
and estimated input tokens; show a conservative maximum cost only for explicitly
known pricing. Stream text to memory and the reading view, then atomically write
the current summary and an immutable `Summaries/` revision only after the stream
finishes. Store provider ID/name, model, template ID/name, date, and revision
path in `session.json` through the reload-before-mutate actor. Leave map-reduce
for a separate committed Part 2.

**Alternatives:** Write each chunk directly to `summary.md`; replace an earlier
summary before the provider succeeds; infer provenance by parsing one of three
fixed badges; send without confirmation to keyless remote endpoints; guess
prices for custom or unknown models; begin chunking in the same change.

**Reasoning:** Streaming is presentation state, not proof of a completed
artifact. Deferring the durable swap makes a mid-stream network or provider
failure harmless to the previous summary and ensures notes are never used as an
output file. Host locality, not key requirement, determines whether meeting text
leaves the Mac. Structured, append-only provenance keeps a six-month-old result
auditable and supports any provider name. A separate Part 1 commit remains a
complete short-transcript feature if implementation or API usage limits stop
work before map-reduce.
